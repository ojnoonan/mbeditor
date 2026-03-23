const testing = (props) => {
    const { children } = props;

    const h1 = <h1>TEST</h1>;

    return (
        <TEST>
            <Hello />
            {children}
            {h1}
        </TEST>
    );
}